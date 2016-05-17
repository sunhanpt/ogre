/*
-----------------------------------------------------------------------------
This source file is part of OGRE
(Object-oriented Graphics Rendering Engine)
For the latest info, see http://www.ogre3d.org

Copyright (c) 2000-2016 Torus Knot Software Ltd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
-----------------------------------------------------------------------------
*/

#include "Vao/OgreMetalVaoManager.h"
#include "Vao/OgreMetalStagingBuffer.h"
#include "Vao/OgreMetalVertexArrayObject.h"
#include "Vao/OgreMetalBufferInterface.h"
#include "Vao/OgreMetalConstBufferPacked.h"
#include "Vao/OgreMetalTexBufferPacked.h"
#include "Vao/OgreMetalUavBufferPacked.h"
#include "Vao/OgreMetalMultiSourceVertexBufferPool.h"
#include "Vao/OgreMetalAsyncTicket.h"

#include "Vao/OgreIndirectBufferPacked.h"

#include "OgreRenderQueue.h"

#include "OgreTimer.h"
#include "OgreStringConverter.h"

namespace Ogre
{
    MetalVaoManager::MetalVaoManager() :
        mDrawId( 0 )
    {
        mConstBufferAlignment   = 256;
        mTexBufferAlignment     = 256;

        mConstBufferMaxSize = 64 * 1024;        //64kb
        mTexBufferMaxSize   = 128 * 1024 * 1024;//128MB

        mSupportsPersistentMapping  = true;
        mSupportsIndirectBuffers    = false;

        mDynamicBufferMultiplier = 1;

        VertexElement2Vec vertexElements;
        vertexElements.push_back( VertexElement2( VET_UINT1, VES_COUNT ) );
        uint32 *drawIdPtr = static_cast<uint32*>( OGRE_MALLOC_SIMD( 4096 * sizeof(uint32),
                                                                    MEMCATEGORY_GEOMETRY ) );
        for( uint32 i=0; i<4096; ++i )
            drawIdPtr[i] = i;
        mDrawId = createVertexBuffer( vertexElements, 4096, BT_IMMUTABLE, drawIdPtr, true );
    }
    //-----------------------------------------------------------------------------------
    MetalVaoManager::~MetalVaoManager()
    {
        destroyAllVertexArrayObjects();
        deleteAllBuffers();
    }
    //-----------------------------------------------------------------------------------
    VertexBufferPacked* MetalVaoManager::createVertexBufferImpl( size_t numElements,
                                                                   uint32 bytesPerElement,
                                                                   BufferType bufferType,
                                                                   void *initialData, bool keepAsShadow,
                                                                   const VertexElement2Vec &vElements )
    {
        MetalBufferInterface *bufferInterface = new MetalBufferInterface( 0 );
        VertexBufferPacked *retVal = OGRE_NEW VertexBufferPacked(
                                                        0, numElements, bytesPerElement,
                                                        bufferType, initialData, keepAsShadow,
                                                        this, bufferInterface, vElements, 0, 0, 0 );

        if( initialData )
            bufferInterface->_firstUpload( initialData, 0, numElements );

        return retVal;
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::destroyVertexBufferImpl( VertexBufferPacked *vertexBuffer )
    {
    }
    //-----------------------------------------------------------------------------------
    MultiSourceVertexBufferPool* MetalVaoManager::createMultiSourceVertexBufferPoolImpl(
                                                const VertexElement2VecVec &vertexElementsBySource,
                                                size_t maxNumVertices, size_t totalBytesPerVertex,
                                                BufferType bufferType )
    {
        return OGRE_NEW MetalMultiSourceVertexBufferPool( 0, vertexElementsBySource,
                                                            maxNumVertices, bufferType,
                                                            0, this );
    }
    //-----------------------------------------------------------------------------------
    IndexBufferPacked* MetalVaoManager::createIndexBufferImpl( size_t numElements,
                                                                 uint32 bytesPerElement,
                                                                 BufferType bufferType,
                                                                 void *initialData, bool keepAsShadow )
    {
        MetalBufferInterface *bufferInterface = new MetalBufferInterface( 0 );
        IndexBufferPacked *retVal = OGRE_NEW IndexBufferPacked(
                                                        0, numElements, bytesPerElement,
                                                        bufferType, initialData, keepAsShadow,
                                                        this, bufferInterface );

        if( initialData )
            bufferInterface->_firstUpload( initialData, 0, numElements );

        return retVal;
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::destroyIndexBufferImpl( IndexBufferPacked *indexBuffer )
    {
    }
    //-----------------------------------------------------------------------------------
    ConstBufferPacked* MetalVaoManager::createConstBufferImpl( size_t sizeBytes, BufferType bufferType,
                                                                 void *initialData, bool keepAsShadow )
    {
        uint32 alignment = mConstBufferAlignment;

        size_t bindableSize = sizeBytes;

        if( bufferType >= BT_DYNAMIC_DEFAULT )
        {
            //For dynamic buffers, the size will be 3x times larger
            //(depending on mDynamicBufferMultiplier); we need the
            //offset after each map to be aligned; and for that, we
            //sizeBytes to be multiple of alignment.
            sizeBytes = ( (sizeBytes + alignment - 1) / alignment ) * alignment;
        }

        MetalBufferInterface *bufferInterface = new MetalBufferInterface( 0 );
        ConstBufferPacked *retVal = OGRE_NEW MetalConstBufferPacked(
                                                        0, sizeBytes, 1,
                                                        bufferType, initialData, keepAsShadow,
                                                        this, bufferInterface, bindableSize );

        if( initialData )
            bufferInterface->_firstUpload( initialData, 0, sizeBytes );

        return retVal;
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::destroyConstBufferImpl( ConstBufferPacked *constBuffer )
    {
    }
    //-----------------------------------------------------------------------------------
    TexBufferPacked* MetalVaoManager::createTexBufferImpl( PixelFormat pixelFormat, size_t sizeBytes,
                                                             BufferType bufferType,
                                                             void *initialData, bool keepAsShadow )
    {
        uint32 alignment = mTexBufferAlignment;

        VboFlag vboFlag = bufferTypeToVboFlag( bufferType );

        if( bufferType >= BT_DYNAMIC_DEFAULT )
        {
            //For dynamic buffers, the size will be 3x times larger
            //(depending on mDynamicBufferMultiplier); we need the
            //offset after each map to be aligned; and for that, we
            //sizeBytes to be multiple of alignment.
            sizeBytes = ( (sizeBytes + alignment - 1) / alignment ) * alignment;
        }

        MetalBufferInterface *bufferInterface = new MetalBufferInterface( 0 );
        TexBufferPacked *retVal = OGRE_NEW MetalTexBufferPacked(
                                                        0, sizeBytes, 1,
                                                        bufferType, initialData, keepAsShadow,
                                                        this, bufferInterface, pixelFormat );

        if( initialData )
            bufferInterface->_firstUpload( initialData, 0, sizeBytes );

        return retVal;
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::destroyTexBufferImpl( TexBufferPacked *texBuffer )
    {
    }
    //-----------------------------------------------------------------------------------
    UavBufferPacked* MetalVaoManager::createUavBufferImpl( size_t numElements, uint32 bytesPerElement,
                                                          uint32 bindFlags,
                                                          void *initialData, bool keepAsShadow )
    {
        MetalBufferInterface *bufferInterface = new MetalBufferInterface( 0 );
        UavBufferPacked *retVal = OGRE_NEW MetalUavBufferPacked(
                                                        0, numElements, bytesPerElement,
                                                        bindFlags, initialData, keepAsShadow,
                                                        this, bufferInterface );

        if( initialData )
            bufferInterface->_firstUpload( initialData, 0, numElements );

        return retVal;
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::destroyUavBufferImpl( UavBufferPacked *uavBuffer )
    {
    }
    //-----------------------------------------------------------------------------------
    IndirectBufferPacked* MetalVaoManager::createIndirectBufferImpl( size_t sizeBytes,
                                                                       BufferType bufferType,
                                                                       void *initialData,
                                                                       bool keepAsShadow )
    {
        const size_t alignment = 4;
        size_t bufferOffset = 0;

        if( bufferType >= BT_DYNAMIC_DEFAULT )
        {
            //For dynamic buffers, the size will be 3x times larger
            //(depending on mDynamicBufferMultiplier); we need the
            //offset after each map to be aligned; and for that, we
            //sizeBytes to be multiple of alignment.
            sizeBytes = ( (sizeBytes + alignment - 1) / alignment ) * alignment;
        }

        MetalBufferInterface *bufferInterface = 0;
        if( mSupportsIndirectBuffers )
        {
            bufferInterface = new MetalBufferInterface( 0 );
        }

        IndirectBufferPacked *retVal = OGRE_NEW IndirectBufferPacked(
                                                        0, sizeBytes, 1,
                                                        bufferType, initialData, keepAsShadow,
                                                        this, bufferInterface );

        if( initialData )
        {
            if( mSupportsIndirectBuffers )
            {
                bufferInterface->_firstUpload( initialData, 0, sizeBytes );
            }
            else
            {
                memcpy( retVal->getSwBufferPtr(), initialData, sizeBytes );
            }
        }

        return retVal;
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::destroyIndirectBufferImpl( IndirectBufferPacked *indirectBuffer )
    {
        if( mSupportsIndirectBuffers )
        {
        }
    }
    //-----------------------------------------------------------------------------------
    VertexArrayObject* MetalVaoManager::createVertexArrayObjectImpl(
                                                            const VertexBufferPackedVec &vertexBuffers,
                                                            IndexBufferPacked *indexBuffer,
                                                            OperationType opType )
    {
        size_t idx = mVertexArrayObjects.size();

        const int bitsOpType = 3;
        const int bitsVaoGl  = 2;
        const uint32 maskOpType = OGRE_RQ_MAKE_MASK( bitsOpType );
        const uint32 maskVaoGl  = OGRE_RQ_MAKE_MASK( bitsVaoGl );
        const uint32 maskVao    = OGRE_RQ_MAKE_MASK( RqBits::MeshBits - bitsOpType - bitsVaoGl );

        const uint32 shiftOpType    = RqBits::MeshBits - bitsOpType;
        const uint32 shiftVaoGl     = shiftOpType - bitsVaoGl;

        uint32 renderQueueId =
                ( (opType & maskOpType) << shiftOpType ) |
                ( (idx & maskVaoGl) << shiftVaoGl ) |
                (idx & maskVao);

        MetalVertexArrayObject *retVal = OGRE_NEW MetalVertexArrayObject( idx,
                                                                        renderQueueId,
                                                                        vertexBuffers,
                                                                        indexBuffer,
                                                                        opType );

        return retVal;
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::destroyVertexArrayObjectImpl( VertexArrayObject *vao )
    {
        MetalVertexArrayObject *glVao = static_cast<MetalVertexArrayObject*>( vao );
        OGRE_DELETE glVao;
    }
    //-----------------------------------------------------------------------------------
    StagingBuffer* MetalVaoManager::createStagingBuffer( size_t sizeBytes, bool forUpload )
    {
        sizeBytes = std::max<size_t>( sizeBytes, 4 * 1024 * 1024 );
        MetalStagingBuffer *stagingBuffer = OGRE_NEW MetalStagingBuffer( 0, sizeBytes, this, forUpload );
        mRefedStagingBuffers[forUpload].push_back( stagingBuffer );

        return stagingBuffer;
    }
    //-----------------------------------------------------------------------------------
    AsyncTicketPtr MetalVaoManager::createAsyncTicket( BufferPacked *creator,
                                                         StagingBuffer *stagingBuffer,
                                                         size_t elementStart, size_t elementCount )
    {
        return AsyncTicketPtr( OGRE_NEW MetalAsyncTicket( creator, stagingBuffer,
                                                            elementStart, elementCount ) );
    }
    //-----------------------------------------------------------------------------------
    void MetalVaoManager::_update(void)
    {
        VaoManager::_update();

        unsigned long currentTimeMs = mTimer->getMilliseconds();

        if( currentTimeMs >= mNextStagingBufferTimestampCheckpoint )
        {
            mNextStagingBufferTimestampCheckpoint = (unsigned long)(~0);

            for( size_t i=0; i<2; ++i )
            {
                StagingBufferVec::iterator itor = mZeroRefStagingBuffers[i].begin();
                StagingBufferVec::iterator end  = mZeroRefStagingBuffers[i].end();

                while( itor != end )
                {
                    StagingBuffer *stagingBuffer = *itor;

                    mNextStagingBufferTimestampCheckpoint = std::min(
                                                    mNextStagingBufferTimestampCheckpoint,
                                                    stagingBuffer->getLastUsedTimestamp() +
                                                    currentTimeMs );

                    /*if( stagingBuffer->getLastUsedTimestamp() - currentTimeMs >
                        stagingBuffer->getUnfencedTimeThreshold() )
                    {
                        static_cast<MetalStagingBuffer*>( stagingBuffer )->cleanUnfencedHazards();
                    }*/

                    if( stagingBuffer->getLastUsedTimestamp() - currentTimeMs >
                        stagingBuffer->getLifetimeThreshold() )
                    {
                        //Time to delete this buffer.
                        delete *itor;

                        itor = efficientVectorRemove( mZeroRefStagingBuffers[i], itor );
                        end  = mZeroRefStagingBuffers[i].end();
                    }
                    else
                    {
                        ++itor;
                    }
                }
            }
        }

        if( !mDelayedDestroyBuffers.empty() &&
            mDelayedDestroyBuffers.front().frameNumDynamic == mDynamicBufferCurrentFrame )
        {
            waitForTailFrameToFinish();
            destroyDelayedBuffers( mDynamicBufferCurrentFrame );
        }

        mDynamicBufferCurrentFrame = (mDynamicBufferCurrentFrame + 1) % mDynamicBufferMultiplier;
    }
    //-----------------------------------------------------------------------------------
    uint8 MetalVaoManager::waitForTailFrameToFinish(void)
    {
        return mDynamicBufferCurrentFrame;
    }
    //-----------------------------------------------------------------------------------
    MetalVaoManager::VboFlag MetalVaoManager::bufferTypeToVboFlag( BufferType bufferType )
    {
        return static_cast<VboFlag>( std::max( 0, (bufferType - BT_DYNAMIC_DEFAULT) +
                                                    CPU_ACCESSIBLE_DEFAULT ) );
    }
}

